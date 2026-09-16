--[[
    The one place the Address List version is written down.

    The window caption, the About block, the diagnostics block and the line
    the entry file logs at startup all read it from here. No other file in the
    segment carries a version number of its own, so this is the only number
    that ever has to be raised.

    Nothing here touches Cheat Engine, so it loads on any Lua 5.3.
]]

local Version = {
    Major = 1,
    Minor = 0,
    Patch = 0,
    Name = "Manifold Address List",
    Author = { "Leunsel", "LeFiXER" }
}

--- Only the number. The window caption puts this after the middle dot.
function Version.String()
    return string.format("%d.%d.%d", Version.Major, Version.Minor, Version.Patch)
end

--- The name and the number together, which is what a log block is titled with.
function Version.Full()
    return Version.Name .. " " .. Version.String()
end

--- Everyone who wrote it, as one line for the status block.
function Version.Authors()
    return table.concat(Version.Author, ", ")
end

return Version
