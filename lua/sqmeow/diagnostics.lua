--- Query errors, shown where the SQL is.
---
--- A database error in a message scrolls away, and says nothing about which of the statements in
--- the buffer it came from. The engine sends the failing statement's line range with the error, so
--- it can be a diagnostic instead: sitting on the offending lines, listed by every diagnostic
--- interface the user already has, and cleared when the query next succeeds.

local M = {}

M.namespace = vim.api.nvim_create_namespace('sqmeow.diagnostics')

--- Build a diagnostic from an error payload.
---
---@param payload table The `call:state` payload for a failed query.
---@return vim.Diagnostic
function M.build(payload)
  local first = payload.start_line or 0
  local last = payload.end_line or first

  return {
    lnum = first,
    end_lnum = last,
    col = 0,
    severity = vim.diagnostic.severity.ERROR,
    source = 'sqmeow',
    message = payload.error or 'the query failed',
  }
end

--- Put an error on the buffer the query came from.
---
---@param buf integer|nil Nothing is shown when the query did not come from a buffer.
---@param payload table
function M.set(buf, payload)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.diagnostic.set(M.namespace, buf, { M.build(payload) })
end

--- Clear the plugin's diagnostics from a buffer.
---
---@param buf integer|nil
function M.clear(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.diagnostic.reset(M.namespace, buf)
end

return M
