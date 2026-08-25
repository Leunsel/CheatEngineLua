--[[
    Process provider: facts about the attached target process and the module
    containing the injection address.
]]

local Provider = { Name = "Process" }

function Provider.Register(registry, services)
    local ce = services.CE
    local function formatAddress(ctx, address)
        if type(address) ~= "number" then return nil end
        if ctx:Get("IsTarget64Bit") then return string.format("%016X", address) end
        return string.format("%08X", address)
    end
    local function moduleNameAt(address)
        if not address or not ce:InModule(address) then return nil end
        local value = ce:GetNameFromAddress(address, true, false)
        if type(value) ~= "string" then return nil end
        return value:match("^(.*)[+-]%x+$") or value
    end
    return registry:RegisterProvider{
        Name = Provider.Name,
        Variables = {
            Process = {
                Type = "string",
                Description = "Attached process name",
                Resolve = function()
                    local name = ce:GetProcessName()
                    if not name then error("No target process is attached", 0) end
                    return name
                end
            },
            ProcessBase = {
                Type = "string",
                Description = "Base address of the process main module, formatted",
                DependsOn = { "Process", "IsTarget64Bit" },
                Resolve = function(ctx)
                    local base = ce:GetAddressSafe(ctx:Get("Process"))
                    return formatAddress(ctx, base) or "No process base found."
                end
            },
            IsTarget64Bit = {
                Type = "boolean",
                Description = "True when the target is a 64-bit process",
                Resolve = function() return ce:IsTarget64Bit() end
            },
            PointerType = {
                Type = "string",
                Description = "'dq' on x64, 'dd' on x86",
                DependsOn = { "IsTarget64Bit" },
                Resolve = function(ctx) return ctx:Get("IsTarget64Bit") and "dq" or "dd" end
            },
            PointerSize = {
                Type = "number",
                Description = "8 on x64, 4 on x86",
                DependsOn = { "IsTarget64Bit" },
                Resolve = function(ctx) return ctx:Get("IsTarget64Bit") and 8 or 4 end
            },
            DefaultPointerBytes = {
                Type = "number",
                Description = "Identical to PointerSize (2.x compatibility)",
                DependsOn = { "PointerSize" },
                Resolve = function(ctx) return ctx:Get("PointerSize") end
            },
            Module = {
                Type = "string",
                Description = "Module containing the injection address",
                DependsOn = { "AddressValue" },
                Hint = "The selected address must be inside a loaded module. Dynamically allocated memory has no module to scan in.",
                Resolve = function(ctx)
                    local module = moduleNameAt(ctx:Get("AddressValue"))
                    if not module then
                        error("Injection address is not inside a loaded module", 0)
                    end
                    return module
                end
            },
            ModuleBase = {
                Type = "string",
                Description = "Base address of that module, formatted",
                DependsOn = { "Module", "IsTarget64Bit" },
                Resolve = function(ctx)
                    local base = ce:GetAddressSafe(ctx:Get("Module"))
                    return formatAddress(ctx, base) or "No module base found."
                end
            }
        }
    }
end

return Provider