--- Resolves filesystem paths under `core.path`.
---
--- All persistent state — the engine binary, saved connections, scratchpads,
--- and the query log — lives under one root.

local M = {}

--- Returns the normalized root directory.
---@return string # Absolute path to `core.path`.
function M.root()
  return vim.fs.normalize(require('sqmeow.config').get().core.path)
end

--- Returns where an installed engine binary is kept.
---@return string # Absolute path to the `bin` directory.
function M.bin()
  return vim.fs.joinpath(M.root(), 'bin')
end

--- Returns the path to the saved connections file.
---@return string # Absolute path to `connections.json`.
function M.connections()
  return vim.fs.joinpath(M.root(), 'connections.json')
end

--- Returns where scratchpads are stored.
---@return string # Absolute path to the `scratch` directory.
function M.scratch()
  return vim.fs.joinpath(M.root(), 'scratch')
end

--- Returns the path to the query log.
---@return string # Absolute path to `history/log.jsonl`.
function M.history()
  return vim.fs.joinpath(M.root(), 'history', 'log.jsonl')
end

--- Returns where archived result files are kept.
---@return string # Absolute path to `history/results`.
function M.results()
  return vim.fs.joinpath(M.root(), 'history', 'results')
end

return M
