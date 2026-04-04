-- Manifold.UnitTest.lua
-- Tailored test runner for Leunsel/CheatEngineLua -> Manifold.Modules

local TEST_START_TIME = os.date("%Y-%m-%d %H:%M:%S")

print("-=== Running Manifold Unit Tests ===-")
print("Time         : " .. TEST_START_TIME)

if getProcessIDFromProcessName then
  print("Process      : " .. tostring(process or "None"))
end

if getCEVersion then
  print("CE Version   : " .. tostring(getCEVersion()))
end

print("====================================\n")

----------------------------------------------------------------
-- SETTINGS
----------------------------------------------------------------

local TEST_MODE = "deep" -- "safe" | "deep"

local MODULE_SPECS = {
  ["Manifold.AssemblerCommands"] = {
    required = true,
    exports = {},
    behavior = function(ctx)
      ctx:skip("Behavior test skipped (Auto Assembler / CE command registration context dependent)")
    end,
  },

  ["Manifold.AutoAssembler"] = {
    required = true,
    exports = {},
    behavior = function(ctx)
      ctx:skip("Behavior test skipped (AA environment dependent)")
    end,
  },

  ["Manifold.Callbacks"] = {
    required = true,
    exports = {},
    behavior = function(ctx)
      ctx:skip("Behavior test skipped (callback registration is CE runtime dependent)")
    end,
  },

  ["Manifold.CustomIO"] = {
    required = true,
    exports = {
      FileExists = "function",
      DeleteFile = "function",
      ReadFromFile = "function",
      WriteToFile = "function",
      ReadFromFileAsJson = "function",
      WriteToFileAsJson = "function",
      EnsureDataDirectory = "function",
    },
    behavior = function(ctx)
      local ioMod = ctx.module
      local baseDir = (os.getenv("TEMP") or os.getenv("TMP") or ".")
      local textPath = baseDir .. "\\Manifold.UnitTest.CustomIO.txt"
      local jsonPath = baseDir .. "\\Manifold.UnitTest.CustomIO.json"

      local ok, err = ioMod:WriteToFile(textPath, "hello manifold")
      ctx:expect(ok == true, "CustomIO:WriteToFile succeeds" .. (ok and "" or (" -> " .. tostring(err))))

      local content, readErr = ioMod:ReadFromFile(textPath)
      ctx:expect(type(content) == "string", "CustomIO:ReadFromFile returns string")
      ctx:expect(content == "hello manifold", "CustomIO text roundtrip matches" .. (content and "" or (" -> " .. tostring(readErr))))

      local payload = {
        name = "Manifold",
        version = 1,
        enabled = true,
      }

      local okJson, jsonErr = ioMod:WriteToFileAsJson(jsonPath, payload)
      ctx:expect(okJson == true, "CustomIO:WriteToFileAsJson succeeds" .. (okJson and "" or (" -> " .. tostring(jsonErr))))

      local decoded, decodeErr = ioMod:ReadFromFileAsJson(jsonPath)
      ctx:expect(type(decoded) == "table", "CustomIO:ReadFromFileAsJson returns table")
      if type(decoded) == "table" then
        ctx:expect(decoded.name == payload.name, "CustomIO JSON roundtrip preserves name")
        ctx:expect(decoded.version == payload.version, "CustomIO JSON roundtrip preserves version")
        ctx:expect(decoded.enabled == payload.enabled, "CustomIO JSON roundtrip preserves enabled")
      else
        ctx:fail("CustomIO JSON roundtrip failed -> " .. tostring(decodeErr))
      end

      local exists = ioMod:FileExists(textPath)
      ctx:expect(exists == true, "CustomIO:FileExists returns true for created file")

      local delOk1 = ioMod:DeleteFile(textPath)
      ctx:expect(delOk1 == true, "CustomIO:DeleteFile deletes text file")

      local delOk2 = ioMod:DeleteFile(jsonPath)
      ctx:expect(delOk2 == true, "CustomIO:DeleteFile deletes json file")

      if type(ioMod.DataDir) == "string" and ioMod.DataDir ~= "" then
        local ensureOk = ioMod:EnsureDataDirectory()
        ctx:expect(ensureOk == true, "CustomIO:EnsureDataDirectory succeeds")
      else
        ctx:skip("CustomIO:EnsureDataDirectory skipped (DataDir not initialized as string)")
      end
    end,
  },

  ["Manifold.Helper"] = {
    required = true,
    exports = {},
    behavior = function(ctx)
      ctx:skip("Behavior test skipped (helper API contract not pinned yet)")
    end,
  },

  ["Manifold.Json"] = {
    required = true,
    exports = {
      new = "function",
      encode = "function",
      decode = "function",
      newArray = "function",
      newObject = "function",
      VERSION = "string",
    },
    behavior = function(ctx)
      local JSON = ctx.module

      local encoded = JSON:encode({
        name = "Manifold",
        count = 42,
        enabled = true,
      })

      ctx:expect(type(encoded) == "string", "JSON:encode returns string")

      local decoded = JSON:decode(encoded)
      ctx:expect(type(decoded) == "table", "JSON:decode returns table")

      if type(decoded) == "table" then
        ctx:expect(decoded.name == "Manifold", "JSON roundtrip preserves name")
        ctx:expect(decoded.count == 42, "JSON roundtrip preserves count")
        ctx:expect(decoded.enabled == true, "JSON roundtrip preserves enabled")
      end

      local arr = JSON:newArray({ 1, 2, 3 })
      ctx:expect(type(arr) == "table", "JSON:newArray returns table")

      local obj = JSON:newObject({ a = 1 })
      ctx:expect(type(obj) == "table", "JSON:newObject returns table")

      local newInstance = JSON:new()
      ctx:expect(type(newInstance) == "table", "JSON:new returns table")
      ctx:expect(getmetatable(newInstance) ~= nil, "JSON:new sets metatable")
    end,
  },

  ["Manifold.Logger"] = {
    required = true,
    exports = {
      Levels = "table",
      LevelNames = "table",
      Warning = "function",
      Error = "function",
      ForceWarning = "function",
      ForceError = "function",
      ForceCritical = "function",
    },
    behavior = function(ctx)
      local logger = ctx.module

      ctx:expect(type(logger.Levels.DEBUG) == "number", "Logger.Levels.DEBUG exists")
      ctx:expect(type(logger.Levels.INFO) == "number", "Logger.Levels.INFO exists")
      ctx:expect(type(logger.Levels.WARNING) == "number", "Logger.Levels.WARNING exists")
      ctx:expect(type(logger.Levels.ERROR) == "number", "Logger.Levels.ERROR exists")
      ctx:expect(type(logger.Levels.CRITICAL) == "number", "Logger.Levels.CRITICAL exists")

      local ok1, err1 = pcall(function() logger:Warning("[UnitTest] Warning") end)
      ctx:expect(ok1 == true, "Logger:Warning callable" .. (ok1 and "" or (" -> " .. tostring(err1))))

      local ok2, err2 = pcall(function() logger:Error("[UnitTest] Error") end)
      ctx:expect(ok2 == true, "Logger:Error callable" .. (ok2 and "" or (" -> " .. tostring(err2))))

      local ok3, err3 = pcall(function() logger:ForceWarning("[UnitTest] ForceWarning") end)
      ctx:expect(ok3 == true, "Logger:ForceWarning callable" .. (ok3 and "" or (" -> " .. tostring(err3))))

      local ok4, err4 = pcall(function() logger:ForceError("[UnitTest] ForceError") end)
      ctx:expect(ok4 == true, "Logger:ForceError callable" .. (ok4 and "" or (" -> " .. tostring(err4))))

      local ok5, err5 = pcall(function() logger:ForceCritical("[UnitTest] ForceCritical") end)
      ctx:expect(ok5 == true, "Logger:ForceCritical callable" .. (ok5 and "" or (" -> " .. tostring(err5))))
    end,
  },

  ["Manifold.Memory"] = {
    required = true,
    exports = {},
    behavior = function(ctx)
      ctx:skip("Behavior test skipped (memory/process dependent)")
    end,
  },

  ["Manifold.Patcher"] = {
    required = true,
    exports = {},
    behavior = function(ctx)
      ctx:skip("Behavior test skipped (patching is target/runtime dependent)")
    end,
  },

  ["Manifold.ProcessHandler"] = {
    required = true,
    exports = {},
    behavior = function(ctx)
      ctx:skip("Behavior test skipped (attached process dependent)")
    end,
  },

  ["Manifold.State"] = {
    required = true,
    exports = {
      New = "function",
      GetStateFilePath = "function",
      SaveTableState = "function",
      ReadStateFile = "function",
    },
    behavior = function(ctx)
      local State = ctx.module

      local okNew, instanceOrErr = pcall(function()
        return State:New()
      end)

      if not okNew then
        ctx:skip("State:New skipped/faulted due to runtime dependencies -> " .. tostring(instanceOrErr))
        return
      end

      local state = instanceOrErr
      ctx:expect(type(state) == "table", "State:New returns table")

      local nilRead = state:ReadStateFile(nil)
      ctx:expect(nilRead == nil, "State:ReadStateFile(nil) returns nil")

      if TEST_MODE == "deep" then
        local baseDir = (os.getenv("TEMP") or os.getenv("TMP") or ".")
        local jsonPath = baseDir .. "\\Manifold.UnitTest.State.json"
        local customIO = CETrequire("Manifold.CustomIO")

        local payload = {
          Records = {
            { Description = "Health", Active = true },
            { Description = "Ammo", Active = false },
          }
        }

        local okWrite, errWrite = customIO:WriteToFileAsJson(jsonPath, payload)
        ctx:expect(okWrite == true, "Deep State setup JSON write succeeded" .. (okWrite and "" or (" -> " .. tostring(errWrite))))

        local readBack = state:ReadStateFile(jsonPath)
        ctx:expect(type(readBack) == "table", "State:ReadStateFile(valid json) returns table")

        customIO:DeleteFile(jsonPath)
      else
        ctx:skip("Deep State file-read test disabled (TEST_MODE ~= 'deep')")
      end
    end,
  },

  ["Manifold.Teleporter"] = {
    required = true,
    exports = {},
    behavior = function(ctx)
      ctx:skip("Behavior test skipped (3D game/runtime/UI dependent)")
    end,
  },

  ["Manifold.UI"] = {
    required = true,
    exports = {},
    behavior = function(ctx)
      ctx:skip("Behavior test skipped (GUI/theme runtime dependent)")
    end,
  },

  ["Manifold.Utils"] = {
    required = true,
    exports = {},
    behavior = function(ctx)
      ctx:skip("Behavior test skipped (utility contract not pinned yet)")
    end,
  },
}

----------------------------------------------------------------
-- INTERNALS
----------------------------------------------------------------

local totals = {
  pass = 0,
  fail = 0,
  skip = 0,
}

local perModule = {}
local failures = {}
local skips = {}

local function ensureStats(moduleName)
  if not perModule[moduleName] then
    perModule[moduleName] = { pass = 0, fail = 0, skip = 0 }
  end
  return perModule[moduleName]
end

local function pass(moduleName, message)
  totals.pass = totals.pass + 1
  ensureStats(moduleName).pass = ensureStats(moduleName).pass + 1
  print("[PASS] [" .. moduleName .. "] " .. message)
end

local function fail(moduleName, message)
  totals.fail = totals.fail + 1
  ensureStats(moduleName).fail = ensureStats(moduleName).fail + 1
  failures[#failures + 1] = "[" .. moduleName .. "] " .. message
  print("[FAIL] [" .. moduleName .. "] " .. message)
end

local function skip(moduleName, message)
  totals.skip = totals.skip + 1
  ensureStats(moduleName).skip = ensureStats(moduleName).skip + 1
  skips[#skips + 1] = "[" .. moduleName .. "] " .. message
  print("[SKIP] [" .. moduleName .. "] " .. message)
end

local function expect(moduleName, condition, message)
  if condition then
    pass(moduleName, message)
  else
    fail(moduleName, message)
  end
end

local function isAllowedType(v)
  local t = type(v)
  return
    t == "nil" or
    t == "boolean" or
    t == "number" or
    t == "string" or
    t == "function" or
    t == "table" or
    t == "userdata"
end

local function makeCtx(moduleName, moduleTable)
  local ctx = {
    moduleName = moduleName,
    module = moduleTable,
  }

  function ctx:pass(message) pass(self.moduleName, message) end
  function ctx:fail(message) fail(self.moduleName, message) end
  function ctx:skip(message) skip(self.moduleName, message) end
  function ctx:expect(condition, message) expect(self.moduleName, condition, message) end

  return ctx
end

----------------------------------------------------------------
-- TEST RUNNER
----------------------------------------------------------------

for moduleName, spec in pairs(MODULE_SPECS) do
  print("\n--- Testing " .. moduleName .. " ---")

  local okLoad, moduleOrErr = pcall(CETrequire, moduleName)
  expect(moduleName, okLoad, "Module loads")

  if not okLoad then
    if spec.required then
      fail(moduleName, "Load error -> " .. tostring(moduleOrErr))
    else
      skip(moduleName, "Optional module unavailable -> " .. tostring(moduleOrErr))
    end
  else
    local moduleTable = moduleOrErr

    expect(moduleName, type(moduleTable) == "table", "Module returns table")

    if type(moduleTable) == "table" then
      for k, v in pairs(moduleTable) do
        expect(moduleName, type(k) == "string", "Export key is string: " .. tostring(k))
        expect(moduleName, isAllowedType(v), "Export value type valid: " .. tostring(k) .. " -> " .. type(v))
      end

      local exports = spec.exports or {}
      if next(exports) == nil then
        skip(moduleName, "No explicit export contract defined")
      else
        for memberName, expectedType in pairs(exports) do
          expect(
            moduleName,
            type(moduleTable[memberName]) == expectedType,
            memberName .. " is " .. expectedType .. " (got " .. type(moduleTable[memberName]) .. ")"
          )
        end
      end

      if type(spec.behavior) == "function" then
        local okBehavior, errBehavior = pcall(function()
          spec.behavior(makeCtx(moduleName, moduleTable))
        end)

        if not okBehavior then
          fail(moduleName, "Behavior test crashed -> " .. tostring(errBehavior))
        end
      else
        skip(moduleName, "No behavior test defined")
      end
    end
  end
end

----------------------------------------------------------------
-- SUMMARY
----------------------------------------------------------------

print("\n====================================")
print("Test Summary")
print("====================================")
print("Passed       : " .. totals.pass)
print("Failed       : " .. totals.fail)
print("Skipped      : " .. totals.skip)

print("\nPer Module:")
for moduleName, stats in pairs(perModule) do
  print(string.format(
    "  %-26s PASS: %-4d FAIL: %-4d SKIP: %-4d",
    moduleName,
    stats.pass,
    stats.fail,
    stats.skip
  ))
end

if #failures > 0 then
  print("\nFailures:")
  for i, msg in ipairs(failures) do
    print(string.format("  %d. %s", i, msg))
  end
end

if #skips > 0 then
  print("\nSkipped:")
  for i, msg in ipairs(skips) do
    print(string.format("  %d. %s", i, msg))
  end
end

print("\n=== Test complete at " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===")