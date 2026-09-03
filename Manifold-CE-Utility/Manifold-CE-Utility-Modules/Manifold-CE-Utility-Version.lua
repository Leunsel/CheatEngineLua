--[[
    Single source of truth for the CE Utility version.

    README, the About entry and the startup line all read from here.
    Nothing else in the tree carries its own version number.
]]

local Version = {
    Major = 2,
    Minor = 0,
    Patch = 0,
    Name = "Manifold CE Utility"
}

function Version.String()
    return string.format("%d.%d.%d", Version.Major, Version.Minor, Version.Patch)
end

function Version.Full()
    return Version.Name .. " " .. Version.String()
end

return Version
