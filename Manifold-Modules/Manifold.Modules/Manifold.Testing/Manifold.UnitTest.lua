-- Manifold.UnitTests.lua

local startTime = os.date("%Y-%m-%d %H:%M:%S")
print("-=== Running Manifold Unit Tests ===-")
print("Time\t: " .. startTime)
if getProcessIDFromProcessName then
  print("Process\t: " .. (process or "None"))
end
if getCEVersion then
  print("CE Version\t: " .. getCEVersion())
end
print("===========================\n")

local modules = {
  "Manifold.AutoAssembler",
  "Manifold.CustomIO",
  "Manifold.Helper",
  "Manifold.Json",
  "Manifold.Logger",
  "Manifold.Memory",
  "Manifold.ProcessHandler",
  "Manifold.State",
  "Manifold.Teleporter",
  "Manifold.UI",
  "Manifold.Utils",
}

local passed, failed = 0, 0

local function assert(condition, message)
  if condition then
    print("[PASS] " .. message)
    passed = passed + 1
  else
    print("[FAIL] " .. message)
    failed = failed + 1
  end
end

local function isValidMemberType(v)
  local validTypes = {
    ["function"] = true,
    ["table"] = true,
    ["string"] = true,
    ["boolean"] = true,
    ["number"] = true,
    ["userdata"] = true, -- For GUI stuff
    ["nil"] = true       -- Sometimes keys are predeclared but unset
  }
  return validTypes[type(v)]
end

for _, name in ipairs(modules) do
  local success, module = pcall(CETrequire, name)
  assert(success, "Module loads: " .. name)
  if success then
    if type(module) == "table" then
      for k, v in pairs(module) do
        assert(type(k) == "string", name .. " contains key: " .. tostring(k))
        assert(isValidMemberType(v), name .. " member type is valid: " .. tostring(k))
      end
    else
      assert(false, name .. " should return a table")
    end
  end
end

print(string.format("\nTest Summary: %d passed, %d failed", passed, failed))
print("=== Test complete at " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===")