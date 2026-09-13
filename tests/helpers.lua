-- What more than one test file needs. Loaded with `dofile`, since `tests/` is not on the runtime
-- path and only files named `test_*.lua` are collected as cases.

local M = {}

--- Put a value in a table's field and answer with what was there.
---
--- By key rather than by assignment, so one field can be swapped in several cases of the same file
--- without each of them redefining it.
---
---@param target table
---@param key string
---@param value any
---@return any original
function M.swap(target, key, value)
  local original = target[key]
  target[key] = value
  return original
end

--- Replace a field for the rest of the case, and put the original back when the case ends.
---
---@param target table
---@param key string
---@param value any
function M.stub(target, key, value)
  local original = M.swap(target, key, value)
  MiniTest.finally(function()
    target[key] = original
  end)
end

return M
