--- Where the plugin keeps the files it writes.
---
--- Everything lives under one directory, `core.path`: the installed engine, saved connections,
--- scratchpads, and the query log with the results it shows again. Moving all of it is one option
--- rather than one per file, and removing it is removing one directory.
---
--- Read from the configuration on every call rather than remembered, so changing `core.path`
--- takes effect without anything having to be told.

local M = {}

--- The directory everything is kept under.
---@return string
function M.root()
  return vim.fs.normalize(require('sqmeow.config').get().core.path)
end

--- Where an installed engine is kept.
---@return string
function M.bin()
  return vim.fs.joinpath(M.root(), 'bin')
end

--- The file saved connections are written to.
---@return string
function M.connections()
  return vim.fs.joinpath(M.root(), 'connections.json')
end

--- Where scratchpads are kept.
---@return string
function M.scratch()
  return vim.fs.joinpath(M.root(), 'scratch')
end

--- The query log.
---@return string
function M.history()
  return vim.fs.joinpath(M.root(), 'history', 'log.jsonl')
end

--- Where the results of logged queries are kept, one file each.
---@return string
function M.results()
  return vim.fs.joinpath(M.root(), 'history', 'results')
end

return M
