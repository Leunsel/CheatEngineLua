--[[
    The one place the SigMaker version is written down.

    The README, the About entry and the line printed at startup all read it
    from here. No other file in the tree carries a version number of its own,
    so this is the only number that ever has to be raised.
]]

local Version = {
    Major = 1,
    Minor = 0,
    Patch = 0,
    Name = "Manifold SigMaker"
}

function Version.String()
    return string.format("%d.%d.%d", Version.Major, Version.Minor, Version.Patch)
end

function Version.Full()
    return Version.Name .. " " .. Version.String()
end

return Version
